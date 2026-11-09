# 3D map bikes (generator)

Renders the 3D rider-on-motorcycle images the app uses on the ride maps (`assets/map_bikes/`)
and in the garage (`assets/garage_bikes/`). Original procedural models (no brand designs), built
with three.js and rendered in headless Chromium.

| File | What |
|---|---|
| `bikes.js` | The models: 8 bike types, rider and pillion (helmet, visor, shoulders, arms on the bars, legs). Every mesh is tagged `paint` or `base`. |
| `render.js` / `render.html` | Lighting (room environment + key / rim / hemisphere, soft self shadows), the passes and the 2D post steps (shadow blur, light rim, gloss to alpha). |
| `generate.mjs` | Renders every type × riders, downsizes (Lanczos, 4× supersampled) and writes palette PNGs at 1x / 2.0x / 3.0x. |
| `composite.js` | Composites layers exactly like the app's painter (`bike_rider_marker.dart`). |
| `preview.mjs` | Contact sheets (`--mode sheet` / `zoom`) and owner previews (`--mode map` / `garage`). |

## Telling the types apart at marker size

At the cockpit marker size (~57 px) the rider covers the middle of the bike, so every type is
recognised by what shows around the rider: its outline, the front and the tail.

| Type | Mark from above |
|---|---|
| commuter | slim tank, simple flat square seat, **light carrier rack** (grid) past the tail |
| scooter | wide apron at the front, bulbous rear body |
| sport | narrow pointed fairing, clip-ons with hand guards, long thin tail |
| cruiser | long, low, wide bars forward, chrome |
| adventure | tall beak, panniers and top box (square tail) |
| offroad | very narrow, long fenders front and back, wide bars |
| electric | no engine or exhaust: sleek pointed teardrop shell, **cyan light strip along each flank**, cyan nose bar, wide hub motor with cyan rings in the rear wheel |
| retro | **round headlight with a flat chrome ring** (an "O"), **twin round mirrors** on stalks, round tank with a chrome centre strip, wide flat bench with a tan stitching band, upright rider on a tall bar |

Check with `preview.mjs --mode types --size 57` (8 types, 1 rider and with pillion, red / black /
white, light and dark map) after any model change.

## Layers

Map images are a top-down view (narrow perspective lens straight down, screen up = bike forward),
64 × 64 logical px. The app turns them by the rider's heading.

1. `shadow` – soft ground shadow, black with alpha. The app turns it with the bike and offsets it
   in screen space by (0.8, 2.0) × size / 64 (light from the top left), opacity 0.9.
2. `base` – everything not painted: tyres, chrome, seat, lights, rider gear and helmets (the
   pillion has a light helmet and jacket), plus a faint light rim so dark bikes read on dark maps.
   Painted panels are filled dark grey here (a panel edge reads as a panel gap, never a hole).
3. `paint` – only the painted panels in white / grey shading. The app multiplies it with the
   bike's colour (`BlendMode.modulate`: rgb × colour, alpha kept); very dark colours are lifted a
   little first (`BikeSprites.paintArgb`).
4. `gloss` – clear-coat highlights of the paint, white with alpha, drawn on top.

Garage heroes (`<type>_<0|2>_<base|paint|gloss>.png`, 128 × 80 logical) are a 3/4 front-right view
with no rider or two, the ground shadow baked into `base`.

Names: `assets/map_bikes/<type>_<1|2>_<layer>.png`, types `commuter scooter sport cruiser
adventure offroad electric retro` (= `BikeType` wire ids).

## Regenerate

Nothing is installed into the repo. In any scratch folder:

```sh
npm init -y && npm i three@0.187.0 sharp playwright   # playwright: npx playwright install chromium
node <repo>/tool/map_bikes/generate.mjs                 # writes <repo>/assets/map_bikes, garage_bikes
node <repo>/tool/map_bikes/generate.mjs --only sport,cruiser --no-hero
node <repo>/tool/map_bikes/preview.mjs --mode sheet --size 57 --png sheet.png
node <repo>/tool/map_bikes/preview.mjs --mode types --size 57 --png types_57px.png
node <repo>/tool/map_bikes/preview.mjs --mode map --png preview_map.png
node <repo>/tool/map_bikes/preview.mjs --mode garage --png preview_garage.png
```

`--out <dir>` writes the assets under another root (for trying changes). The scripts resolve
`three`, `sharp` and `playwright` from the current directory.

Tuning knobs: `PAINT_WIDEN` / `RIDER_SCALE` in `bikes.js` (map legibility: panels a little wider,
riders a little slimmer, top view only), `TOP_SPAN` and the fit margin in `render.js`, rim / shadow
strength in `renderTop`. After changing the layer maths, change `composite.js` and the Dart painter
together.
