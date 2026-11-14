# CoRoute round 13: new helmet logo everywhere (ships in build 3.55.0+10030)

Round 13 is in the working tree, uncommitted, next to rounds 11-12. All three ship together as build 3.55.0+10030
(pubspec already 3.55.0+10030). Give the release agent the round 11 prompt
(docs/NEXT_AGENT_PROMPT_v3.55_round11_redesign_website.md) AND this one. Paste everything inside the block.

```
You are the release agent for CoRoute. Rounds 11-12 (redesign, ride HUD, website story, Play graphics) and round 13
(new logo) are uncommitted in the working tree and ship together as build 3.55.0+10030. Follow the round 11 prompt
for everything there; this prompt adds the logo. Report after each section. STOP at any failed safety gate.

=== 0. RULES ===
- Same rules as round 11 (no secrets/IPs in git; never weaken SOS, crash alarm, warnings, Medical ID, ride lock,
  lock-screen cockpit, app lock; policy scan 0 hits; fix code, not tests, unless a text changed on purpose).
- Read first: docs/brand/BRAND_GUIDE_v3.58.md (files, colours, rules, release checklist).
- Never edit logo PNGs by hand: change tool/brand/build_brand.py and run `python3 tool/brand/build_brand.py`
  (fontTools + rsvg-convert), then `node tool/store_assets/render.js` for the Play graphics and website screenshots.

=== 1. WHAT IS NEW (round 13) ===
New logo chosen by the owner: the rider's helmet is the "o" of CoRoute (visor = the road ahead, amber light = the
lead rider). The old curved-road mark is retired everywhere.
A) App (Android): launcher icon (legacy, round, adaptive foreground, teal background), NEW monochrome layer for
   Android 13+ themed icons, android:roundIcon, splash icon. NEW notification small icon drawable/ic_stat_coroute.xml
   (white helmet) used by the ride notification and push messages (Kotlin), the ride foreground service
   (BackgroundService.rideNotificationIcon + manifest meta-data space.devmonks.coroute_app.NOTIFICATION_ICON), the
   crash alarm (alarm_notifier.dart) and Firebase's own notifications (manifest default_notification_icon/color).
   res/raw/keep.xml keeps the icon from resource shrinking (Dart refers to it by name).
   Before: the small icon was the full-colour launcher icon (shows as a white blob on Android 7+).
B) App (screens): lib/core/ui/coroute_logo.dart draws the logo in code (CoRouteAppIcon, CoRouteWordmark,
   CoRouteHelmet). Used on splash, welcome, sign-in, update-required, licences page, admin consoles (AdminBrandMark),
   and the shared ride card image. Tests updated on purpose: application_level_test (splash shows the wordmark),
   share_card_quick_reply_test (card shows the wordmark).
C) iOS AppIcon set and Flutter web icons regenerated (iOS not shipped yet; files only).
D) Play: store/icon_512.png (full square, no alpha), feature graphic with the wordmark, the 8 phone + tablet
   screenshots re-rendered (Welcome now shows the wordmark).
E) Website: favicon.svg/32 px, apple-touch-icon, icon-192/512 + maskable, site.webmanifest (teal theme), header and
   footer wordmark (icon only below 380 px), receipt mark, og-image.png, /brand/ files. Website screenshots
   re-rendered.
F) E-mails (gateway/src/email_brand.js): every template now shows the wordmark image (/brand/email-wordmark.png,
   alt text "CoRoute" in teal) and uses teal instead of the old purple: welcome/lifecycle, offers, marketing studio,
   receipts/refunds. Security e-mails keep NO images (test rule): teal text header, teal buttons. Ride summary map
   line is teal. Admin e-mail previews recoloured.

=== 2. COMMIT (after the round 11 commits, before "chore(release): 3.55.0+10030") ===
"feat(brand): helmet logo masters and generator (docs/brand, tool/brand)",
"feat(app): helmet launcher, themed and notification icons, logo in screens",
"feat(website): helmet logo, favicons, manifest, og image; e-mail brand header",
"docs(store): Play icon, feature graphic and screenshots with the new logo". Push.
IMPORTANT: the top-level .gitignore (line 29 "*.xml", and a png rule) ignores NEW files, so `git add` silently skips
them. Force-add and check with `git status --short --ignored`:
  git add -f android/app/src/main/res/drawable/ic_stat_coroute.xml android/app/src/main/res/raw/keep.xml \
    android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml \
    android/app/src/main/res/mipmap-*/ic_launcher_round.png android/app/src/main/res/mipmap-*/ic_launcher_monochrome.png \
    docs/brand/png
Without them a clean checkout fails to build (manifest and Kotlin refer to them). ALSO already ignored before this
round and therefore probably missing from git: android/app/src/main/res/values/share_in.xml,
android/app/src/main/res/values-night/colors.xml, android/app/src/main/res/drawable/ride_notif_pill_sos_solid.xml.
Check `git ls-files` for each; if missing, force-add them too and report. Better: narrow the *.xml / png rules in the
top-level .gitignore so Android resources are never ignored (keep secrets rules as they are).

=== 3. TEST AND BUILD (in addition to round 11) ===
1. gateway npm test -> 1458 passing (e-mail and website tests touched: purchase_email_355, security_357,
   jobs8_producers, website).
2. flutter analyze; flutter test (updated: test/e2e/application_level_test.dart, test/share_card_quick_reply_test.dart).
   Golden or screenshot tests that include the splash/welcome/sign-in header may need new goldens: regenerate only
   those, and say which.
3. Release build: aapt2 must accept ic_stat_coroute.xml, ic_launcher_round.xml and res/raw/keep.xml. Check in the
   release APK (apkanalyzer or unzip) that res/drawable*/ic_stat_coroute* and mipmap*/ic_launcher_monochrome* exist
   (resource shrinking did not drop them).

=== 4. DEVICE QA (release build; phone model + Android version) ===
L1 launcher icon on Android 8, 12, 13+; themed icons ON (Android 13+ wallpaper colours) shows the helmet; round-icon
   launcher; Samsung One UI.
L2 status bar + shade: ride notification, foreground service, push message, crash alarm full-screen and heads-up:
   white helmet, never a white square or the old mark. Accent teal.
L3 splash (light + dark), Welcome, sign-in, update-required screen, licences page, admin console header.
L4 share a ride card: image shows the wordmark in light and dark.
L5 Play internal testing listing shows the new icon after upload.
SAFETY GATE (any failure = STOP): crash countdown + alarm over the lock screen still fires with the new icon; SOS
notification actions (I'm OK, SOS) still work from the lock screen.

=== 5. WEBSITE + E-MAIL CHECKS (after release.sh) ===
W-L1 favicon in Chrome, Firefox, Safari; iOS "Add to Home Screen" icon; Android Chrome install icon (maskable).
W-L2 header/footer wordmark in light, dark and at 360 px (icon only); receipt page mark.
W-L3 link preview (og-image) in WhatsApp/Telegram (may need a cache-busting share).
W-L4 test e-mails to Gmail and Outlook, images on and off: welcome, receipt, an offer, a security code (no images).

=== 6. GOOGLE PLAY ===
Upload store/icon_512.png as the app icon and docs/store/play_assets_v3.58/feature_graphic_1024x500.png, plus the
re-rendered screenshots (after the round 11 section 6 real-capture check). The icon change is reviewed with the
release.

=== 7. REPORT ===
Add to the round 11 report: logo QA table L1-L5, W-L1-W-L4, any golden tests regenerated, APK resource check result.
```
