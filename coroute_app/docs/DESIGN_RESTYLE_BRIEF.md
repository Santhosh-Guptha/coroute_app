# Restyle brief — CoRoute Rider App Screens (design canvas → Flutter)

Repo copy: `/home/claude/coroute_app` (Flutter app, `lib/`). Design artboards (HTML+inline CSS, one per screen):
`/tmp/claude-0/-home-claude/d7dbae80-97a6-5f85-ab80-48e31422d6c3/scratchpad/artifact-files/7dce6288-9ce9-4663-92b2-2e6db3a94f7b/project/<Name>.dc.html`
(`Home, Main (navigation while riding), Orbit, Intercom, Riders, Fuel, Route, Guardian, SOS, Stop, More, Summary, Trips, Alerts, Profile, Admin`). The `*Dark.dc.html` files are just the same screen with the dark palette — ignore them; our palette already has both.

## Goal
Restyle the EXISTING screens in place so they look like the artboards. Keep every service, provider, callback, navigation route, l10n string and test hook wired exactly as it is. Change layout, spacing, colours, typography, iconography and component shapes — not behaviour. Where the artboard shows a feature the app does not have, do not invent data; keep the real content and style it like the closest artboard element.

## Foundation (already done — build on it, do not re-do)
- `lib/core/theme/app_palette.dart` / `app_theme.dart`: canvas tokens. Use the NEW getters in restyled code:
  `AppTheme.bg, card, soft, map, road, border, border2, tint, brand (#0B6E78 solid), accentText (teal for text/icons), warnText, warnTint, warnBorder, sos (#C8102E), text, text2, muted`. Legacy names (`slateCard`, `neonCyan`, …) still compile and now map onto these, so untouched files keep working.
- Font: `Manrope` is the ThemeData `fontFamily` (variable TTF in `assets/fonts/`). Weights used by the canvas: 600 body, 700 labels, 800 titles/buttons.
- `lib/core/ui/ui_tokens.dart`: `AppText.headline (22/800), title (16/800), body (15/600), label (13/600 muted), overline (12/800, letterSpacing 1.5, uppercase), caption (12/600), metric (32/800)`. `Radii.md=14, lg=18, xl=22, sheet=28`.
- `lib/core/ui/design_kit.dart` (exported from `core/ui/ui.dart`): `DsCard` (2 px border, 18 px radius; `accent`, `warning`, `tinted`, `dashed`), `DsHeroCard` (solid teal, white text; `DsHeroCard.overline` / `.secondary` colours), `DsSectionHeader`, `DsScreenHeader` (round back button + title/subtitle), `DsRoundButton` (44 px), `DsButton` (tones brand/sos/onHero/outline/warn), `DsChip` (LEAD/BEST/REGROUP…), `DsIconTile` (dock tiles), `DsAvatar` (initials; outlined/filled/warning), `DsListRow`, `DsSwitchRow`, `DsStatCell`, `DsSegment`, `DsProgressBar`, `dsFloatingShadow()`, `dsScreenPadding`. Use these instead of hand-rolling. If you need a new primitive, add it to YOUR screen file as a private widget — do not edit `design_kit.dart` (one owner only).

## Canvas conventions to reproduce
- Screen padding 20 px sides, 28 px bottom; SafeArea on top. Vertical rhythm: 18–22 px between blocks, 10–12 px between cards in a list.
- Cards: `card` fill, 2 px `border`, radius 18; hero cards solid `brand` radius 22; sheets radius 28 top with a 44×5 `border2` handle.
- Buttons: 56 px tall, radius 16, weight 800; primary = solid teal + white; destructive = `sos` red; on a hero card = white card with teal text.
- Icons: Material rounded outline icons (`Icons.*_rounded` / `_outlined`), teal `accentText` by default, 22–26 px; never emoji.
- Section headers: uppercase 12/800 muted with 1.5 letter-spacing.
- Status: warnings use `warnText` on `warnTint` with `warnBorder`; teal `tint` behind accent chips.
- Map screens: top floating pill (card, radius 20, shadow), round 60 px Orbit button at left with 3 px teal ring, bottom dock = card radius 22 with a 6-tile grid (SOS red tile first), then a ride-summary card at the very bottom.
- Bottom nav: 4 items (Home / Trips / Alerts / Profile), labels 12/800, selected teal, others muted, hairline top border, bg = `bg`.
- Keep touch targets ≥ 44 px and real `Semantics` labels on icon-only buttons.

## Hard rules
- Edit ONLY the files assigned to you. If something you need lives in another agent's file, describe the change in your final report instead of editing.
- No Flutter/Dart toolchain is available here: you cannot run `flutter analyze`. Be meticulous: balanced brackets, trailing commas, imports for everything you use (`../../core/ui/ui.dart` gives you the kit, tokens and theme is `../../core/theme/app_theme.dart`), no `const` on widgets that read `AppTheme.*` getters (they are not compile-time constants). `withOpacity` is fine (already used in the codebase); `withValues(alpha:)` also works (Flutter ≥ 3.44).
- Do not rename public classes, constructors, parameters or keys that tests may reference. Check `test/` for widget tests touching your screens (`grep -rl <ClassName> test/`) and keep the finder targets (texts, Keys, tooltips) they look for.
- Keep `const` constructors where they already exist and still compile.
- When done, reply with: files changed, what each now looks like, anything you could not map, and any text/Key that changed which a test might assert on.
