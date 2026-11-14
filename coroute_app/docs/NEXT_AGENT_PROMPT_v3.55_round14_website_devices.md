# CoRoute round 14: website works on every device (ships with build 3.55.0+10030)

Round 14 is in the working tree, uncommitted, next to rounds 11-13. It changes only the website (gateway/public),
two gateway tests and a CSS tool: no app change, no new server code. Give the release agent the round 11 prompt, the
round 13 prompt AND this one. Paste everything inside the block.

```
You are the release agent for CoRoute. Rounds 11-14 ship together as build 3.55.0+10030 (round 11 = redesign, 13 =
logo, 14 = website device compatibility). Follow the round 11 and 13 prompts; this adds round 14. Report after each
section. STOP at any failed safety gate.

=== 0. RULES ===
- Same rules as round 11. Read first: docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md (targets, the 16 problems found and
  fixed, real-device QA table D1-D7) and tool/web_compat/README.md.
- After ANY website CSS change (including your own fixes): cd tool/web_compat && npm install && node css_compat.js.
  Never hand-edit lines marked /* compat */ or compat:generated. Do not commit tool/web_compat/node_modules.

=== 1. WHAT IS NEW (round 14) ===
- Header and footer never make the page scroll sideways: Galaxy Fold 280 px, system text 150-200 %
  (site.js fitHeader(), footer grid, wrapping buttons, overflow-wrap).
- Older iPhones/Android browsers: site.js no longer crashes on Safari < 14 (matchMedia listener); keyboard focus ring
  restored on Safari < 15.4; CSS fallbacks for clamp/min/max, svh, color-mix, inset, logical margins/paddings, flex
  gap (.no-flexgap from theme-init.js), split :has()/:focus-visible selector lists, -webkit-backdrop-filter,
  aspect-ratio boxes; scroll story shows still frames where aspect-ratio is missing; /watch guardian page rewritten to
  ES2019; photo editor button hidden where it cannot work.
- iPhone landscape safe areas; <noscript> notices on the 10 pages that need JavaScript; low-end phones (<= 2 GB RAM or
  <= 2 cores) get the still hero poster.
- Brand name spelled "CoRoute" everywhere on the website (was "Coroute" in titles, footer, live/join pages).
- New test gateway/test/website_device_compat_358.test.js (7 checks); website.test.js and live_page.test.js updated
  for the "CoRoute" spelling (text changed on purpose).

=== 2. COMMIT (before "chore(release): 3.55.0+10030") ===
"fix(website): works on every device (narrow and large-text layouts, older Safari/Chrome fallbacks, safe areas)",
"chore(tool): web_compat CSS fallback tool", "test(website): device compatibility guards". Push.

=== 3. TEST ===
1. gateway npm test -> 1465 passing (1458 + 7 new). cd tool/web_compat && npm install && node css_compat.js --check
   -> "up to date".
2. Website screenshots and Play graphics are unchanged by round 14 (no re-render needed).

=== 4. DEPLOY + REAL-DEVICE QA (after release.sh staging -> vm2 -> vm1) ===
Run D1-D7 from docs/quality/WEBSITE_DEVICE_COMPAT_v3.58.md on staging first, then production:
D1 old iPhone Safari (iOS 12.5-14.x if available), D2 current iPhone portrait+landscape, D3 Galaxy Fold folded /
Samsung Internet, D4 low-end Android, D5 Android largest font + display size, D6 iPad + desktop Firefox/Safari/Edge,
D7 JavaScript off. If no old iPhone is available, use a cloud device service or BrowserStack-like free tier, and say
which devices were real. Any page that scrolls sideways or a menu that does not open = fix + re-run css_compat.js.
SAFETY GATE for the website: /watch (guardian live link) and /e/<token> (live emergency link) must open and update on
an old iPhone and a current Android; the SOS/live pages must never be blank.

=== 5. REPORT ===
Add to the round 11/13 report: D1-D7 table (device, OS, browser, result), test counts, css_compat --check result.
```
