# Prompt: finish the CoRoute design-canvas restyle

Paste everything below into Claude Code (or Cowork) opened on `wise-chandrasekhar/coroute_app`, on branch `design-canvas-restyle`.

---

You are finishing a UI restyle of the CoRoute Flutter app (`coroute_app/`) to match the "CoRoute Rider App Screens" design canvas (https://claude.ai/artifact/GY32U4ija9VMzTd6Yo66Vg — 15 rider screens light+dark, plus an Admin console). The restyle has already been applied to 93 files on branch `design-canvas-restyle`, but **it has never been compiled** (no Flutter SDK was available). Your job is to make it compile, pass tests, and close the gaps below. Read `docs/DESIGN_RESTYLE_BRIEF.md` first — it defines the tokens, the design kit and the rules.

## What already exists (do not redo)
- `lib/core/theme/app_palette.dart`, `app_theme.dart`: canvas tokens (`AppTheme.bg, card, soft, map, road, border, border2, tint, brand, accentText, warnText, warnTint, warnBorder, sos, text, text2, muted`), legacy names mapped onto them, Manrope as `fontFamily`.
- `assets/fonts/Manrope-Variable.ttf` + `fonts:` entry in `pubspec.yaml`.
- `lib/core/ui/ui_tokens.dart` (AppText.headline/overline, Radii.xl, sheet 28) and `lib/core/ui/design_kit.dart` (DsCard, DsHeroCard, DsButton, DsChip, DsIconTile, DsAvatar, DsListRow, DsSwitchRow, DsStatCell, DsSegment, DsProgressBar, DsScreenHeader, DsRoundButton…).
- Restyled: home + bottom nav, live cockpit (top pill, markers, dock, orbit, stop modal, quick settings), ride sheet (spread hero, riding order, invite card), intercom, riders ladder, fuel/essentials, trip planner/route panel/review, guardian, SOS hold + crash alarm + SOS sheet, incident/assist/hazard banners, safety settings, trip report (summary), trips, alerts, account/profile (includes More-style settings groups), timeline, auth/onboarding/splash, all admin screens (`AdminShell` rail + KPI tiles + tables).

## Step 1 — make it build (must do first)
1. `flutter pub get`
2. `flutter analyze` — fix every **error** (warnings/infos only if introduced by this branch: compare with `git diff main --stat`). Typical things to expect: a `const` constructor wrapping something that reads an `AppTheme.*` getter (remove the `const`), missing imports for `design_kit.dart` / `app_theme.dart`, a `switch` on `DsButtonTone` needing exhaustiveness, `withValues` vs `withOpacity` (both fine on Flutter ≥ 3.44), circular imports between `admin/master_admin_dashboard.dart` and the admin screens (allowed, but fix if analyzer complains).
3. `flutter test` — fix failures by adjusting the **UI code**, not by weakening tests, unless the test asserts on an old cosmetic detail that the design intentionally changed (e.g. a section title now uppercase, a `SwitchListTile` that became `DsSwitchRow`, `IconButton` → `DsRoundButton`). For those, update the finder minimally and note it. Known risk spots reported by the agents:
   - `account_screen.dart` (profile subline now e-mail; section headers uppercase), `alerts_screen.dart` (filter is no longer `SegmentedButton`), `data_saver_tile.dart` (no longer `SwitchListTile`), `group_settings_sheet.dart` (spoken-alert rows are `DsSwitchRow`), admin screens (no `AppBar`; refresh/replay are `DsRoundButton` with tooltip), `admin_users_screen.dart` possible overflow at 320 dp + 1.3× text (drop the "Active" pill if so), `cockpit_shortcuts_dock.dart` (7 tiles; narrow-width scroll fallback), `permissions_screen.dart` (status is a `DsChip`).
4. Run the app on a phone/emulator in **both** light and dark (Profile → Theme) and walk every screen: Home → Start ride → cockpit → Orbit → each Orbit tile → SOS (cancel!) → stop → ride end → summary → Trips → Alerts → Profile → Admin (with an admin account). Fix overflows (yellow/black stripes), clipped text, and unreadable contrast.

## Step 2 — close the gaps the agents could not map
- **More screen (`More.dc.html`)**: in `account_screen.dart` add a 56 px avatar profile card at the top if missing, a "Bike & map" group, rename "Theme" → "Night mode" (keep the same action), and a "Ride history" outlined button at the bottom that opens Trips.
- **Dark-mode SOS**: none needed (the SOS screen is always red) — just confirm it.
- **Navigation pill limit badge**: in `minimal_cockpit_overlay.dart`, show the "LIMIT 80" badge in neutral `tint`/`accentText` when under the limit and in `warnText`/`warnTint` only when over (the canvas shows it amber even when under — that was a design bug).
- **Road name subtitle** on the top pill: if the route/geo services expose the current road or next step name, show it instead of the convoy name; otherwise leave as is.
- Leave out features with no data source (per-rider mic state, intercom channel "Lead only", guardian contacts list, admin demo tables). Do not invent data.

## Step 3 — finish
- `flutter analyze` clean of errors, `flutter test` green.
- Update `PROJECT_CONTEXT.md` with one line: UI follows the CoRoute design canvas; tokens in `core/theme`, primitives in `core/ui/design_kit.dart`.
- Commit on `design-canvas-restyle` with a clear message; do not merge to main or push without asking me.
- Report: what you fixed, any test finders you changed and why, and screenshots (light + dark) of Home, cockpit, Orbit, Group, Fuel, SOS, Summary, Profile, Admin.
