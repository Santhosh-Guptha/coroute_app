# Round 12: website in the v3.58 style, the home scroll story, Play Store graphics

Owner request: "update the whole website with visualisation and our new app screens and on scrolling based loading
with a story of riders with this application and provide the screens for playstore to upload in the play console".
Earlier constraint kept: the home page keeps the moving-convoy hero (round 7, `assets/hero3d.js`) and shows **no
phone screenshots**; the new screens go on the other pages.

Build unchanged (3.55.0+10029). Nothing in `lib/` or `android/` was touched.

## 1. What changed, page by page

| Page | Change |
|---|---|
| `/` (index.html) | New `#story` section right after the hero: "A ride with CoRoute", seven chapters with a sticky, scroll-driven SVG stage (section 2). The "SOS that works without signal" card now names the offline link (per hop). JSON-LD description and `featureList` name the offline link, rescue beacon and finder, curve and limit warnings (est.), noise reduction, ride stats, ride summary e-mail. Every other section, anchor and nav link is unchanged. Still no phone screens. |
| `/features` | All six phone pictures replaced with v3.58 renders (crash check, group list, ride screen, community, trip report, home). New `#ride-screen` section (turn card, one advisory at a time, speed against the limit, offline link, hold to end) with the night curve-warning screen. New `#screens-tour`: a sideways strip of 10 screens (keyboard-scrollable region). Copy: rescue beacon and finder, "Curves, limits and hazards" (est.), "Noise reduction", group list. Jump nav has 8 entries. |
| `/safety` | Crash section ends with the crash-check and SOS-sent screens. New `#rescue` (beacon and finder, honest ranges: Bluetooth roughly 30 to 100 m, siren and locator sound tens of metres, "helps riders find you in the last stretch") and `#offline-link` (a few hundred metres per hop; chain, not a phone property). "No network at all" card rewritten. Jump nav: Rescue finder, No signal. |
| `/how-it-works` | A row of four screens under the four steps (home, explore, ride, trip report). Ride step mentions curve warnings and the offline link. |
| `/get` | New "What you are installing" row (welcome, home, night ride screen). Permissions: the old "Bluetooth connect: never asked" row was wrong since round 10; it is now "Nearby devices (Bluetooth), recommended" with what it is for (offline link, rescue beacon, headsets) and that it is not used for location. Android 7.0 minimum unchanged. |
| `/guide` | Solo / group / join steps name the new + quick actions (with the old labels for older versions). Two screens under "Start a solo ride". "Remember on every ride" adds the offline link and Nearby devices. Permissions table row for Nearby devices updated. |
| plans, clubs, operators, leaderboard, trip, account, legal | No content change. They already share site.css (tokens, Manrope, light / dark, cards, buttons) with the app's v3.55/v3.58 palette; checked in light, dark and reduced motion at 360 / 768 / 1440. Plans keep their price rules (prices only from the catalog). |
| Shared CSS | `pages.css`: `.shots` strip, `.pg-shot`, `.pg-split`, `.pg-shots-row`, app-style `.chip`s; `.hm-facts` with an odd number of items no longer leaves an empty cell. `legal.css`: `.guide-shots`. `home.css`: the story layout and the story SVG classes. |
| Screenshots | `gateway/public/assets/screens/`: regenerated from the v3.58 mocks at the size the pages declare (636 x 1386, plus 480 and 320; AVIF + WebP + a 480 PNG). New names: home, explore, community, profile, ride, intercom, stats, curve, group, noroute, crash, sos, finder, offline, trip, people, welcome. Removed (old design, no longer referenced): dark, guardians, sirens. |

## 2. The story

### Script

Fictional crew, Indian first names: **Meera** (lead), **Imran** (sweep), **Kiran**, **Asha**, **Dev**, **Ravi**,
riding as the Sunday Sunrise Crew. Stated on the page: "They are made up; everything the app does for them is real."

| # | Chapter | Text (summary) | Visual (scroll drives it) |
|---|---|---|---|
| 1 | Planning the Sunday ride (Friday, 9 pm) | Crew poll (Sunday 5:30 wins 5 to 1), route with fuel and breakfast stops, join code, pre-ride check (location always, battery, emergency contact, Nearby devices). | Route draws on a map; pins appear; poll bars grow; six avatars pop in; checklist ticks turn green. |
| 2 | Rolling out together (5:40 am) | One live map, Meera lead, Imran sweep; hands-free intercom with noise reduction; nothing recorded. | Six riders move along the road with Lead / Sweep tags; the intercom waveform turns from noisy to clean. |
| 3 | Bends, limits and a hazard ahead (6:50 am) | "Hairpin right, comfortable 25"; limit in view, estimates marked est. and never spoken; gravel reported ahead. | Switchback road, a rider climbing; warning card, "~40 est." sign, hazard pin. |
| 4 | The signal drops (7:30 am) | Offline link: the group's phones pass messages along, a few hundred metres per hop; Imran's message reaches Meera via Asha, Dev, Kiran. | Forest, signal bars crossed out; ~300 m arcs link the bikes; a pulse hops along the chain; the message card appears. |
| 5 | A rider falls behind (8:10 am) | Kiran stops; at about a kilometre the sweep and lead are told; regroup at the fuel stop. | Gap label grows 0.2 to 1.2 km; alert card; regroup pin; everyone converges. |
| 6 | The crash (10:05 am) + Find Ravi | 30 s check, no answer; SMS to family (no data), group alerted via server and offline link, live link; beacon siren. Crew turns back; GPS gets them close; "Find Ravi" hotter / colder meter in the last stretch; call 112, stay with him. Honest note on ranges. | Countdown ring 30 to 0, "No answer"; SOS ripples and three outputs; cross-fade to the finder gauge, ~100 m down to ~8 m. |
| 7 | Everyone home (evening) | Ravi fine; trip report; ride summary e-mail; family followed the live link. | Line chart "Speed over the ride (km/h)", 0 to 128 km, dashed group limit 60 labelled directly; tiles 128 km / 3 h 42 m / 3 stops; two chips. Example values from the story. |

### How it works

* **Text first.** All chapter text, headings and a text alternative per visual (`figcaption.sr-only`) are in
  `index.html`. Keyboard users read it in order; "Skip the story" jumps to `#standout`.
* **Progressive loading.** `home.js` injects `/assets/story.js` (8 KB gzip) when the section is within 1200 px
  (IntersectionObserver). If it fails, `data-state="fallback"` returns to text-only chapters.
* **Motion allowed** (and JS on): CSS picks the live layout from the first paint (`.js` from theme-init.js +
  `prefers-reduced-motion: no-preference`), so nothing shifts when the script arrives. Desktop: sticky stage on the
  left (6:5), chapters on the right. Under 900 px: the stage sticks under the header (up to 46 vh), the chapter cards
  scroll beneath it. The chapter crossing the reading line picks the scene; its scroll progress (0 to 1) drives the
  drawing. A light animation loop (riders, waveform, ripples) runs only while the section is on screen and the tab is
  visible.
* **Reduced motion:** no stage; each chapter shows its static frame beside the text, drawn by the same code as each
  figure approaches. Same text.
* **No JavaScript:** each figure shows a saved frame through `<noscript><img loading="lazy" width height>`
  (`/assets/story/*.svg`, 7 to 13 KB each, light and dark by `prefers-color-scheme`).
* **Measured:** CLS 0 (reduced motion) and below 0.00001 (live) at 360 / 768 / 1440; no horizontal scroll at 360.

### How to edit a chapter

1. Text: edit the chapter's `<li class="st__step">` in `gateway/public/index.html` (heading, paragraphs, and the
   `figcaption` text alternative if the visual changes). Keep `data-scene` and the `data-frame` / `data-p` values.
2. Visual: each scene is one function in `gateway/public/assets/story.js` (`SCENES.plan`, `roll`, `ghat`, `forest`,
   `behind`, `crash`, `home`). It builds SVG once and returns `draw(p, t)`: `p` is the chapter's scroll progress,
   `t` seconds (0 for static frames). Use `seg(p, a, b)` to time a step inside the chapter. Colours only through the
   `s-*` classes in `home.css` (between `story-svg:start` and `story-svg:end`), so light, dark and the saved frames
   follow the site tokens.
3. A new chapter: add a `<li class="st__step" data-scene="x">` with its figure, a `SCENES.x`, a dot in `.st__dots`,
   and a name in `tool/store_assets/story_frames.js` (`NAMES`).
4. Regenerate the no-JS frames: `node tool/store_assets/story_frames.js`.
5. Run `cd gateway && node --test test/website*.test.js` (the story test checks the chapters, figures, frames and
   the script rules).

## 3. Page weight (Chromium, 1440 x 900, whole page scrolled, cold cache)

| Page | Before (raw / gzip-equivalent) | After | Main additions |
|---|---|---|---|
| `/` | 380 KB / 118 KB | 426 KB / 131 KB | story.js 24.3 KB (8.1 KB gz, lazy), home.css +9.5 KB (+1.9 KB gz), HTML +11.5 KB (+3 KB gz), home.js +0.9 KB |
| `/features` | 328 KB / 142 KB | 431 KB / 233 KB | 10 more screens (the tour strip, lazy AVIF 9 to 14 KB each), HTML +12.8 KB |
| `/safety` | 238 KB / 63 KB | 286 KB / 106 KB | 4 screens, +6 KB HTML |
| `/get` | 239 KB / 63 KB | 280 KB / 100 KB | 3 screens |
| `/how-it-works` | 227 KB / 61 KB | 283 KB / 112 KB | 4 screens |
| `/guide` | 171 KB / 44 KB | 197 KB / 69 KB | 2 screens |

The home page's first load (above the fold) is unchanged: story.js and its frames load only near the story. Every
screenshot is `loading="lazy"`, `decoding="async"`, with `width`/`height` and `srcset`/`sizes` (AVIF, WebP, PNG).

## 4. Play Store graphics

`docs/store/play_assets_v3.58/` (README there: file list, Console slots, Google's rules with links, listing text,
release notes, and the accuracy note with adb / Android Studio re-capture steps). Generator: `tool/store_assets/`.

## 5. QA checklist (W-items)

| ID | Check | Status here |
|---|---|---|
| W1 | Phone 360 x 800, light and dark: story stage sticks under the header, cards readable, no horizontal scroll | Done (Chromium screenshots) |
| W2 | Tablet 768 x 1024: stage on top, centred, chapter cards below | Done |
| W3 | Desktop 1440 x 900: stage left, chapters right, active chapter highlighted, dots follow | Done |
| W4 | Reduced motion (OS setting): no sticky stage, a static frame per chapter, same text | Done (Playwright reducedMotion) |
| W5 | JavaScript off: chapter text plus saved frames; the rest of the page works | Done |
| W6 | Keyboard only: Tab reaches "Skip the story", every link; the screen strip on /features scrolls with arrow keys when focused | Done (manual reasoning + markup); verify with a real keyboard |
| W7 | Screen reader (TalkBack / VoiceOver): each chapter heading, its text and the figure description are read once, in order; the stage is hidden | To do on devices |
| W8 | Safari on iOS (15+): sticky stage, SVG text, AVIF (16+) with WebP fallback, smooth scrolling without jank | To do (no Safari here) |
| W9 | Firefox desktop and Android | To do |
| W10 | Slow 3G (DevTools throttling): hero text first, story text before the visuals, screenshots fill in lazily without layout shift | To do in DevTools (CLS measured 0 here) |
| W11 | Theme toggle (System / Light / Dark) while in the story: the stage recolours at once | Done |
| W12 | Lighthouse: CLS < 0.1, images sized, lazy below the fold, no console errors, no CSP violations | Done for CLS, sizing, errors; run Lighthouse on the deployed site |
| W13 | Low-end Android (2 GB RAM): story animation stays smooth; it pauses when the section is off screen or the tab is hidden | To do |

## 6. Owner decisions

1. **Screenshots are renders of the design mocks**, not captures from a phone. Re-capture any screen that differs in
   the real build before Play upload (README, "Before publishing"). The website screens should be swapped for real
   captures the same way once the build ships (same file names, run the encoder in `render.js`).
2. **Light screenshots in dark mode.** The website shows one set of screens (mostly light, ride screens partly dark)
   in both themes. A dark set per page would double the images; say if you want it.
3. **Tablet layouts.** The app has no dedicated tablet layout; the tablet shots are the phone layouts at tablet width
   plus the landscape ride screen. Check on a real tablet, or upload only the landscape ride screen and the ones that
   look right (Play needs 4 per tablet type to show them).
4. **Release notes** describe the v3.58 redesign. Use them only for the build that contains it.
5. **Privacy policy wording on Bluetooth** (legal page, not changed here) says CoRoute uses Bluetooth "strictly for
   offline convoy coordination"; the rescue beacon and headset audio also use it. Ask legal to align it with
   docs/PLAYSTORE_PERMISSIONS.md.
6. The offline-link screen shows "No mobile signal" while the status bar shows full signal, because Google asks for
   full status icons. Acceptable, or we hide the signal icon on that one screenshot.
