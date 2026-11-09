# CoRoute design system v3.55

Owner direction: calm, cool and warm, easy on the eyes, simple. Less text, more meaning.
Not jazzy: no neon, no glows, no heavy gradients, no ALL-CAPS headings.

Source of truth in code: `lib/core/theme/app_palette.dart` (tokens), `lib/core/theme/app_theme.dart`
(Material theme + `AppTheme.*` getters), `lib/core/ui/ui_tokens.dart` (spacing, radii, `AppText`),
`lib/core/ui/design_kit.dart` (Ds* components). Contrast check: `python3 tool/design_contrast.py`.
The website uses the same hex values.

## 1. Colour tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| background | `#F6F4F0` | `#15181C` | Screen background (dark is soft charcoal, never pure black) |
| surface | `#FFFFFF` | `#1C2026` | Cards, sheets, dialogs, nav bar |
| surfaceAlt | `#EFECE6` | `#242932` | Inset rows, chips, tiles, disabled fills |
| border | `#E3DED6` | `#2F3540` | Hairlines, dividers, card borders |
| borderStrong | `#CFC8BD` | `#3E4652` | Outline buttons, switch-off track, unselected radio |
| text | `#1F2328` | `#E7E3DC` | Body text (warm off-white in dark) |
| textMuted | `#5B616B` | `#A7A39B` | Secondary text, labels |
| textFaint | `#8A8F96` | `#7C7A75` | Hints and placeholders only (not body text) |
| primary | `#2B7A8C` | `#5FB3C4` | Actions, links, selected, focus |
| onPrimary | `#FFFFFF` | `#0E1A1D` | Text/icons on primary |
| primarySoft | `#D7ECEF` | `#1F3A40` | Selected rows, info chips, nav indicator |
| primaryFill | `#2B7A8C` | `#29707E` | Deep teal that always carries **white** text (hero card, legacy `brand`) |
| accent | `#D9822B` | `#E9A55B` | Warm amber for icons and fills |
| accentSoft | `#F7E6D3` | `#3A2C1D` | Pale amber fill (warning cards) |
| accentStrong | `#94600F` | `#E9A55B` | Amber that is readable as **text** (warning text) |
| accentBorder | `#EBCBA6` | `#5A4228` | Border of warning cards |
| success | `#3E8E5E` | `#6CC08B` | Positive state (pair with icon/text) |
| warning | `#B9821C` | `#E0B15A` | Caution icons/fills |
| danger | `#C8463D` | `#E5675C` | Errors, destructive actions |
| info | `#3D7BC8` | `#79A8E8` | Informational |
| sos | `#D93A2F` | `#FF5A4E` | SOS / crash only. Stays strong and high-contrast |

In Dart: `AppTheme.background`, `AppTheme.surface`, `AppTheme.primary`, `AppTheme.onPrimary`, ...
(new names) - and the old names still work and map onto the tokens:

| Old name | Now |
|---|---|
| `bg`, `obsidianVoid` | background |
| `card`, `slateCard` | surface |
| `soft`, `darkCanvas`, `elevatedCard` | surfaceAlt |
| `border`, `glassBorder`, `subtleBorder` / `border2` | border / borderStrong |
| `text`, `textPrimary` / `text2`, `muted`, `textSecondary`, `textMuted` | text / textMuted |
| `accentText`, `neonCyan`, `electricBlue`, `devmonksPurple` | primary (teal text/icons) |
| `brand`, `heroTop` | primaryFill (white text is safe on it) |
| `tint` | primarySoft |
| `warnText`, `hyperAmber`, `speedWarning` / `warnTint` / `warnBorder` | accentStrong / accentSoft / accentBorder |
| `emeraldSafe` | success |
| `laserRed` | danger |
| `infoBlue` | info |
| `sos` | sos |

Rules: `Colors.white` on a fill is only allowed on `brand`/`primaryFill`, `sos` and `danger`.
On `primary` use `onPrimary` (dark text in the dark theme). Never hard-code hex colours in screens;
never use Material accents (`Colors.greenAccent`, `Colors.redAccent`, `0xFF00E5FF` ...).

Rider (convoy member) colours: 10 muted, distinct hues per theme (`AppPalette.members`).

Map in dark: only OSM light tiles exist (offline packs depend on that URL), so `map_tiles.dart`
applies `softDarkTileFilter` - a low-contrast, slightly warm luminance inversion (land about `#23272C`,
labels about `#A5A29B`). No stark black/white inversion.

## 2. Type (Manrope, bundled)

Sentence case everywhere. Letter-spacing normal (0). Line height 1.4-1.5.
Weights: 400 body, 500 labels/buttons in lists, 600 titles and primary buttons, 700 only for big
numbers (speed, distance) and the SOS label. Avoid 800/900.

| Style (`AppText`) | Size / weight / height | Use |
|---|---|---|
| metric | 32 / 700 / 1.15, tabular | Big ride numbers |
| headline | 22 / 600 / 1.3 | Screen titles |
| title | 16 / 600 / 1.4 | Card and sheet titles |
| body | 15 / 400 / 1.45 | Reading text |
| label | 13 / 500 / 1.4, textMuted | Labels, secondary lines |
| overline | 13 / 600 / 1.4, textMuted | Section header (sentence case, no caps) |
| caption | 12 / 400 / 1.4, textMuted | Timestamps, hints |

`DsSectionHeader` and `DsChip` no longer upper-case their text.

## 3. Shape, space, elevation

- Radius: cards 14 (`Radii.lg`), buttons/inputs/tiles 12 (`Radii.md`), hero 16 (`Radii.xl`),
  sheet top 20 (`Radii.sheet`), chips/pills 999.
- Spacing: 4 / 8 / 12 / 16 / 24 / 32 (`Space.*`). Screen side padding 20-24.
- Borders: 1 px hairline (`border`); outline buttons `borderStrong`.
- Shadow: only `dsFloatingShadow()` (16 blur, 4 y, `shadow` token, about 12 % in light) for things
  floating over the map. No coloured shadows, no glows, no spread.
- Scrim behind sheets/dialogs: `AppScrim.color` = background-dark at 45 %.
- Motion: gentle fades/slides only (`Motion.*`, ease-out cubic, 120-260 ms). No bounce, no loops.

## 4. Components

- **Primary button** (`DsButton`, `FilledButton`): primary fill, onPrimary text, 56 (Ds) / 52 (Material) high,
  radius 12, weight 600, no icon unless it adds meaning. **One primary action per screen.**
- **Secondary** : outline (`DsButtonTone.outline`, `OutlinedButton`) surface + borderStrong; or a plain
  text link (`TextButton`, primary, weight 500).
- **Inputs**: filled surface, 1 px border, radius 12, floating label inside the box (no separate label line),
  outline icon 22 px prefix, focus = primary 1.5 px.
- **Cards** (`DsCard`): surface, 1 px border, radius 14, padding 16. Tinted variant = primarySoft.
- **Chips** (`DsChip`, `Chip`): pill, 12 px weight 500, sentence case, soft fill.
- **Sheets** (`showAppSheet`): surface, radius 20 top, 36x4 handle, title 18/600, content in cards.
- **Dialogs**: surface, radius 16, hairline border, title 20/600, body muted.
- **Snackbars**: inverse (text colour background, background colour text), radius 12, floating.
- **Nav bar**: surface, top hairline, pill indicator primarySoft, selected icon primary, label 12.
- **Switch/checkbox/radio/slider**: primary when on, borderStrong when off.
- **Icons**: outline style (`Icons.*_outlined`), 22-24 px.
- **SOS / crash**: unchanged structure; strong `sos` red, white label, weight 700. Do not soften.

## 5. Do / don't

| Do | Don't |
|---|---|
| One idea per screen, short lines ("Ride together, safely.") | Paragraph explanations |
| Icons + 2-4 word labels | Long button labels ("Register Rider Account") |
| Sentence case ("Bike status") | ALL CAPS headings, letter-spaced labels |
| Tokens via `AppTheme.*` | Hex values, `Colors.amber`, Material accents |
| Flat surfaces, hairlines | Gradients, glows, neon, heavy drop shadows |
| 400/500/600 weights | 800/900 everywhere |
| Plain text links for secondary actions | Several filled buttons competing |

## 6. Contrast (WCAG, checked by `tool/design_contrast.py`)

| Foreground | Light hex | on bg | on surface | Dark hex | on bg | on surface |
|---|---|---|---|---|---|---|
| text | `#1F2328` | 14.38 | 15.80 | `#E7E3DC` | 13.92 | 12.79 |
| textMuted | `#5B616B` | 5.68 | 6.24 | `#A7A39B` | 7.08 | 6.51 |
| textFaint (hints only) | `#8A8F96` | 2.96 | 3.26 | `#7C7A75` | 4.15 | 3.81 |
| primary (links) | `#2B7A8C` | 4.48 | 4.92 | `#5FB3C4` | 7.40 | 6.80 |
| accentStrong (warning text) | `#94600F` | 4.85 | 5.33 | `#E9A55B` | 8.48 | 7.79 |
| danger | `#C8463D` | 4.35 | 4.77 | `#E5675C` | 5.45 | 5.00 |
| sos | `#D93A2F` | 4.16 | 4.57 | `#FF5A4E` | 5.79 | 5.32 |

Fills: onPrimary on primary 4.92 (light) / 7.37 (dark); white on primaryFill 4.92 / 5.66;
text on surfaceAlt 13.40 / 11.42; muted on surfaceAlt 5.29 / 5.81; snackbar 14.38 / 13.92.
White on dark-theme `sos` (`#FF5A4E`) is 3.08: fine for the large bold SOS label (AA large), so
small white text on SOS uses the light `#D93A2F` fill (the Android ride notification does this).
`textFaint` and amber `accent`/`warning` are not for body text; use `textMuted` / `accentStrong`.

## 7. Theme setting

System (default) / Light / Dark (`ThemeController.choices`). The older Automatic (sun) and Light-sensor
choices are folded into System (saved values migrate on load). Night riding (`setRideDarkOverride`) forces
the dark palette and the soft dark map. Android launch window: light `#F6F4F0`, `values-night` `#15181C`.

## 8. Android ride notification (res/values*/ride_notification.xml)

Light: accent `#25697A`, critical `#B23A32`, warning `#85550D`, positive `#2A6E45` on tints
`#EAF3F5 / #FBEBE8 / #FAEFE2 / #EAF4ED` (all >= 5:1); buttons `#EFECE6` / `#1F2328`; SOS `#D93A2F` + white.
Dark: tones = dark tokens on `#1F3A40 / #351F1E / #3A2C1D / #1E3327`; buttons `#242932` / `#E7E3DC`;
SOS `#D93A2F` + white.
