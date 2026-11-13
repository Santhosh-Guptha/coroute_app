# Round 7: website home page (v3.55)

Owner request: "remove the mobile screens in home, don't change other screen mobile pics, and at the top put the
previous vehicles moment animated video".

## What changed

1. **Phone screens removed from the home page only.**
   - Hero: the three phone frames (`.hx__phones`) are gone.
   - "See what you get on the road" gallery (`#screens`): section removed. The page now flows
     Leaderboard -> Features. Nothing linked to `#screens`, and the JSON-LD `screenshot` points at `og-image.png`.
   - Crash / SOS section (`#safe`): the phone picture is replaced by a small "who hears an SOS" graphic
     (`.hp-relay`: pulsing SOS mark + four rows built from the site icons).
   - Memorable section (`#memorable`): the trip-report phone picture is replaced by an example trip card
     (`.hp-trip`: inline SVG routes + four numbers, labelled as an example with demo riders).
   - Other pages (features, guide, get, plans, legal ...) are untouched and the files in
     `gateway/public/assets/screens/` are kept, because those pages use them.
2. **The moving convoy is back at the top.** The earlier animated hero was still in the repo as
   `gateway/public/assets/hero3d.js` (hand-written WebGL, kept "for later use" when the phones went in). It is
   **restored and polished**, not rebuilt:
   - a group of six riders (lead in front, sweeper at the back, staggered formation) rides an endless winding
     mountain road; the camera follows with a slow drift, so near and far terrain move at different speeds (parallax);
   - riders are now small bikes seen from behind (tyre, jacket in the member colour, helmet, tail light) that lean
     into the bends, instead of round map dots; the lead sends a "position update" ping;
   - day palette in the light theme, night palette in the dark theme, cross-faded when the theme changes;
   - desktop (900 px and up): full-bleed behind the headline, road on the right, words on the left over a scrim;
   - phones and tablets: a full-width band at the very top (under the see-through header), headline right below it
     on the plain page colour, so the text contrast does not depend on the picture.
3. **Performance.**
   - No image preloads or `fetchpriority` remain on the home page (the hero has no images now).
   - The scene script is not in the HTML. `home.js` adds it after `load`, in an idle moment. First paint is the
     inline SVG drawing (`.hx__poster`: mountains, road, five rider dots); the canvas fades in over it.
   - The band height is reserved in CSS (`--hx-band`), so there is no layout shift (measured CLS 0).
   - Device pixel ratio capped at 1.5 (1 on very slow devices), 4 draw calls a frame, display rate by default and
     an automatic 30 fps cap when frames take longer than 24 ms, coarser terrain on phones.
   - Paused when the hero is off screen, when the tab is hidden and with reduced motion (measured: 0 frames a second
     in each case).
   - The gallery code was removed from `site.js` (about 2 KB less on every page).
4. **Accessibility.** The scene host is `role="img"` with a text alternative; the canvas and the SVG drawing are
   `aria-hidden`. Reduced motion, save-data, no WebGL, a lost context or a failed script load all leave the static
   drawing in place. Forced colours hides the scene.

## Files

| File | Change |
| --- | --- |
| `gateway/public/index.html` | hero markup (scene host + first-frame drawing), gallery section removed, `.hp-relay` and `.hp-trip` graphics |
| `gateway/public/assets/home.css` | hero layout (band on phones / tablets, full-bleed on desktop), poster colours, `.hp-relay`, `.hp-trip`; phone and gallery styles removed |
| `gateway/public/assets/hero3d.js` | the restored scene: tuning block, bike sprites, lean, adaptive frame rate |
| `gateway/public/assets/home.js` | unchanged (it already lazy-loads the scene for `[data-hero3d]`) |
| `gateway/public/assets/site.js` | gallery code removed |
| `gateway/test/website_live.test.js` | hero test rewritten for the scene; gallery test removed |
| `gateway/test/website.test.js` | `screens` dropped from the list of required home sections |

Asset URLs get their `?v=<hash>` from the gateway at serve time, so there is no hash list to update, and the
site has no service worker for these pages.

## How to tweak the animation

All in `gateway/public/assets/hero3d.js`, block "Tuning" near the top:

| Setting | Default | Meaning |
| --- | --- | --- |
| `SPEED` | `8.5` | riding speed in m/s. 6 is slower and calmer, 12 is brisk |
| `RIDERS` | `6` | bikes in the group, 2 to 8. First is the lead, last the sweeper |
| `GAP` | `7.2` | metres between bikes |
| `NEAREST` | `30` | metres from the camera to the sweeper (smaller: bigger bikes) |
| `MARKERS` | `'bike'` | `'dot'` brings back the round map markers |
| `SLOW_FRAME_MS` | `24` | average frame time above which the scene drops to 30 fps |
| `DPR_CAP` | `1.5` | sharpness cap (keep at 2 or less; the test checks this) |
| `LEAN` | `14` | how hard bikes lean in bends (0: upright) |

Other knobs: road shape `roadX` / `roadH` (must stay identical to the GLSL copy right below them), colours in `DAY`
and `NIGHT`, camera in `render()` (`cy` height, field of view `46` / `58`, and the `-0.4` that pushes the road to the
right of the headline on desktop). Band height on phones / tablets: `--hx-band` in `home.css`.
If the rider count changes, also update the count in the `aria-label` in `index.html` ("a group of six riders").
To switch the animation off without removing it: delete the `data-hero3d` attribute in `index.html`.

## Checks run

- `cd gateway && node --test test/website*.test.js`: 70 pass.
- Every other gateway test that reads `gateway/public`: 301 pass.
- Playwright + Chromium (software WebGL), home page at 360x800, 768x1024, 1440x900, light and dark, with and
  without reduced motion: scene state `live` (or `static` with reduced motion), no console or page errors, no
  horizontal scroll, CLS 0. Three frames a second apart differ (the scene moves). Animation frames per second: 0
  when scrolled away, 0 with reduced motion.

## QA checklist (by eye, on real devices)

- **W1 Phone, light (360 to 430 px wide).** Road band at the top with bikes moving away from you; headline
  "Ride Together. Stay Safe." fully readable below it; no sideways scroll; buttons full width.
- **W2 Phone, dark.** Same, night colours; tail lights and the teal route line visible; text contrast fine.
- **W3 Tablet (768 px, portrait and landscape).** Band at the top in portrait; from 900 px wide the scene fills the
  hero behind the words. Rotate the device: the scene resizes without stretching.
- **W4 Desktop 1440 and wider, light and dark.** Words on the left, road on the right; no bike sits under the
  headline or the lead paragraph. Check a very wide window (1920+) and a short one (700 px tall).
- **W5 Theme switch.** Use the header theme button: the scene cross-fades between day and night within a second.
- **W6 Reduced motion** (Android: Remove animations; iOS: Reduce Motion; desktop OS setting). The hero shows the
  still drawing, nothing moves, no canvas is added.
- **W7 Slow phone.** On a low-end Android the text and buttons appear first, the scene fades in a moment later, and
  scrolling stays smooth (the scene should settle at 30 fps). Battery saver / data saver: the still drawing only.
- **W8 Off-screen and background.** Scroll down and back, switch tabs and return: the ride continues without a jump
  in layout; the device does not get warm while the page sits in a background tab.
- **W9 Safari iOS (not tested here: no device).** Check the band under the notch / address bar, the fade-in, and
  that leaving and returning to Safari restarts the scene. If WebGL is lost, the still drawing must remain.
- **W10 No phone screens on home.** Scroll the whole home page: no app screenshots in phone frames; the SOS section
  shows the red SOS mark with four rows, the Memorable section shows the example trip card.
- **W11 Other pages unchanged.** /features, /guide, /get, /safety still show their phone pictures.
- **W12 Keyboard and screen reader.** Tab order goes header -> hero buttons; the scene is announced once as an
  illustration and the canvas is skipped.
